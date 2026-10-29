package org.servicebroker.deliverypipeline.repo;

import org.servicebroker.deliverypipeline.model.JpaServiceInstance;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

/**
 * Created by Mingu on 2017-05-10.
 */

@Repository
public interface JpaServiceInstanceRepository extends JpaRepository<JpaServiceInstance, String>{
    JpaServiceInstance findByOrganizationGuid(String organizationId);
}
